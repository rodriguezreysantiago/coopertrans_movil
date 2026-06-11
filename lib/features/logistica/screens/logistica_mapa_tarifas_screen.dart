// lib/features/logistica/screens/logistica_mapa_tarifas_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — mapa de tarifas en lenguaje Núcleo.
//
// Mapa con todas las tarifas activas dibujadas sobre OpenStreetMap. Cada
// tarifa = una línea entre origen y destino; cada extremo es un pin
// (AppMapMarker). Filtra automáticamente las tarifas sin coords en las dos
// puntas; el operador ve qué porción del catálogo falta georreferenciar.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - los dos streams (`streamUbicaciones` + `streamTarifas(soloActivas:)`),
//   - el cache de rutas OSRM (`_rutasPorTarifa`, `_yaSolicitadas`,
//     `_precargarRutas`),
//   - el resaltado (`_tarifaResaltadaId`) y el zoom a bounds,
//   - el toggle satélite (`_modoSatelite`) y el panel lateral (`_panelAbierto`),
//   - el diagnóstico granular (`_diagnosticar`, `_DiagnosticoMapa`,
//     `_TarifaFiltrada`) y su sheet,
//   - la dedup de pins (`_buildMarkers`, `_addUnico`),
//   - los botones IR AL ORIGEN/DESTINO (solo mobile) y la guía textual
//     (desktop), `AccionesNavegacionSheet`.
//
// Núcleo: markers via AppMapMarker, pills flotantes via AppMapInfoPill,
// leyenda via AppMapLegend, panel lateral + sheets re-skineados a tokens.
//
// Reglas duras: tokens (context.colors), plata en mono, sin overflow.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_geo_utils.dart';
import '../services/logistica_service.dart';
import '../widgets/acciones_navegacion_sheet.dart';

class LogisticaMapaTarifasScreen extends StatefulWidget {
  const LogisticaMapaTarifasScreen({super.key});

  @override
  State<LogisticaMapaTarifasScreen> createState() =>
      _LogisticaMapaTarifasScreenState();
}

class _LogisticaMapaTarifasScreenState
    extends State<LogisticaMapaTarifasScreen> {
  final _mapCtl = MapController();
  bool _modoSatelite = false;

  /// Cache local de rutas OSRM por id de tarifa. Se va llenando
  /// progresivamente en background. La UI usa la ruta real si está, sino
  /// dibuja línea recta como fallback inmediato.
  final Map<String, GeoRuta> _rutasPorTarifa = {};

  /// Set de tarifas cuyo fetch ya disparé (para no relanzar).
  final Set<String> _yaSolicitadas = {};

  /// Id de la tarifa actualmente resaltada en el mapa (tap en su tile del
  /// panel lateral). Su polyline se dibuja más gruesa + color brand, y el
  /// mapa hace zoom a sus bounds. null = sin resaltar (vista panorámica).
  String? _tarifaResaltadaId;

  /// Panel lateral derecho con buscador + lista de tarifas. Abierto por
  /// default (operador típico está en desktop oficina, tiene espacio).
  bool _panelAbierto = true;

  @override
  void dispose() {
    _mapCtl.dispose();
    super.dispose();
  }

  /// Lanza fetch en background para cada tarifa que aún no tenga ruta local.
  /// Llamado cada vez que se reconstruye la lista de tarifas con coords.
  void _precargarRutas(List<_TarifaConRuta> tarifas) {
    for (final t in tarifas) {
      if (_yaSolicitadas.contains(t.tarifa.id)) continue;
      _yaSolicitadas.add(t.tarifa.id);
      LogisticaGeoUtils.obtenerRuta(t.origen, t.destino).then((ruta) {
        if (!mounted || ruta == null) return;
        setState(() => _rutasPorTarifa[t.tarifa.id] = ruta);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mapa de tarifas',
      actions: [
        IconButton(
          icon: Icon(
              _panelAbierto ? Icons.view_sidebar_outlined : Icons.view_sidebar),
          tooltip: _panelAbierto ? 'Ocultar panel' : 'Mostrar panel',
          onPressed: () => setState(() => _panelAbierto = !_panelAbierto),
        ),
      ],
      body: StreamBuilder<List<UbicacionLogistica>>(
        stream: LogisticaService.streamUbicaciones(),
        builder: (ctx, ubicSnap) {
          final ubicacionesPorId = {
            for (final u in (ubicSnap.data ?? const <UbicacionLogistica>[]))
              u.id: u,
          };
          return StreamBuilder<List<TarifaLogistica>>(
            stream: LogisticaService.streamTarifas(activa: true),
            builder: (ctx, tarSnap) {
              // Errores primero — un stream caído muestra mensaje explícito.
              if (tarSnap.hasError) {
                return AppErrorState(
                  title: 'Error cargando tarifas',
                  subtitle: tarSnap.error.toString(),
                );
              }
              if (ubicSnap.hasError) {
                return AppErrorState(
                  title: 'Error cargando ubicaciones',
                  subtitle: ubicSnap.error.toString(),
                );
              }
              // Spinner SOLO si NINGUNO de los dos emitió todavía.
              if (!tarSnap.hasData && !ubicSnap.hasData) {
                return const AppSkeletonList(count: 6, conAvatar: false);
              }
              final tarifas = tarSnap.data ?? const [];
              final diag = _diagnosticar(tarifas, ubicacionesPorId);
              final tarifasConCoords = diag.conCoords;
              // Disparar precarga de rutas OSRM. Best-effort; las que fallan
              // quedan con línea recta.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _precargarRutas(tarifasConCoords);
              });
              return _buildMapa(
                context,
                tarifasConCoords: tarifasConCoords,
                tarifasFiltradas: diag.filtradas,
                tarifasTotales: tarifas.length,
                ubicacionesPorId: ubicacionesPorId,
              );
            },
          );
        },
      ),
    );
  }

  /// Diagnóstico completo (tarifas OK + filtradas con su motivo). Lo usa el
  /// botón "Diagnóstico" para listar al operador qué tarifa falla y por qué.
  _DiagnosticoMapa _diagnosticar(
    List<TarifaLogistica> tarifas,
    Map<String, UbicacionLogistica> ubicaciones,
  ) {
    final ok = <_TarifaConRuta>[];
    final filtradas = <_TarifaFiltrada>[];
    for (final t in tarifas) {
      final o = ubicaciones[t.ubicacionOrigenId];
      final d = ubicaciones[t.ubicacionDestinoId];

      // Diagnóstico granular: distinguimos cada motivo para guiar al
      // operador a arreglar exactamente lo que falta.
      String? motivo;
      if (o == null) {
        motivo = 'La ubicación de ORIGEN no existe '
            '(id "${t.ubicacionOrigenId}"). Capaz fue borrada — '
            'editá la tarifa y reasigná un origen válido.';
      } else if (o.lat == null || o.lng == null) {
        motivo = 'La ubicación de origen "${o.nombre}" no tiene '
            'coordenadas cargadas. Andá a Ubicaciones, abrí esa '
            'ubicación y tocá "Elegir en mapa".';
      } else if (d == null) {
        motivo = 'La ubicación de DESTINO no existe '
            '(id "${t.ubicacionDestinoId}"). Capaz fue borrada — '
            'editá la tarifa y reasigná un destino válido.';
      } else if (d.lat == null || d.lng == null) {
        motivo = 'La ubicación de destino "${d.nombre}" no tiene '
            'coordenadas cargadas. Andá a Ubicaciones, abrí esa '
            'ubicación y tocá "Elegir en mapa".';
      }

      if (motivo == null) {
        ok.add(_TarifaConRuta(
          tarifa: t,
          origen: LatLng(o!.lat!, o.lng!),
          destino: LatLng(d!.lat!, d.lng!),
          nombreOrigen: o.nombre,
          nombreDestino: d.nombre,
        ));
      } else {
        filtradas.add(_TarifaFiltrada(tarifa: t, motivo: motivo));
      }
    }
    return _DiagnosticoMapa(conCoords: ok, filtradas: filtradas);
  }

  /// Sheet con la lista de tarifas filtradas y el motivo. Útil para que el
  /// operador entienda QUÉ corregir cuando dice "tengo la tarifa cargada
  /// pero no aparece".
  void _mostrarDiagnostico(
    BuildContext context,
    List<_TarifaFiltrada> filtradas,
  ) {
    final c = context.colors;
    showModalBottomSheet(
      context: context,
      backgroundColor: c.surface1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (sheetCtx) {
        final cc = sheetCtx.colors;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          builder: (ctx, controller) {
            return Column(
              children: [
                const SizedBox(height: AppSpacing.sm),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cc.border,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                      AppSpacing.md, AppSpacing.lg, AppSpacing.md),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_outlined, color: cc.warning),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Tarifas que no se muestran en el mapa',
                          style: AppType.h5.copyWith(color: cc.text),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
                    itemCount: filtradas.length,
                    separatorBuilder: (_, __) => Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: AppHairline(color: cc.border),
                    ),
                    itemBuilder: (_, i) {
                      final f = filtradas[i];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${f.tarifa.ubicacionOrigenLimpia} → '
                            '${f.tarifa.ubicacionDestinoLimpia}',
                            style: AppType.body.copyWith(
                              color: cc.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            f.motivo,
                            style: AppType.bodySm.copyWith(color: cc.warning),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildMapa(
    BuildContext context, {
    required List<_TarifaConRuta> tarifasConCoords,
    required List<_TarifaFiltrada> tarifasFiltradas,
    required int tarifasTotales,
    required Map<String, UbicacionLogistica> ubicacionesPorId,
  }) {
    final c = context.colors;
    if (tarifasConCoords.isEmpty) {
      return AppEmptyState(
        icon: Icons.map_outlined,
        title: 'Sin tarifas para mostrar',
        subtitle: tarifasTotales == 0
            ? 'No hay tarifas activas. Cargá tarifas y ubicaciones con coordenadas.'
            : 'Tenés $tarifasTotales tarifa(s) activa(s) pero ninguna con '
                'origen y destino georreferenciado.\n\n'
                'Tocá "Diagnóstico" para ver qué le falta a cada una.',
        action: tarifasFiltradas.isEmpty
            ? null
            : AppButton.secondary(
                label: 'Ver diagnóstico',
                icon: Icons.warning_amber_outlined,
                onPressed: () => _mostrarDiagnostico(context, tarifasFiltradas),
              ),
      );
    }

    // Calcular bbox para encuadre inicial.
    final puntos = <LatLng>[];
    for (final t in tarifasConCoords) {
      puntos.add(t.origen);
      puntos.add(t.destino);
    }
    final bbox = LatLngBounds.fromPoints(puntos);

    return Column(
      children: [
        if (tarifasConCoords.length < tarifasTotales)
          Container(
            color: c.warningSoft,
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: c.warning, size: 16),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Mostrando ${tarifasConCoords.length} de '
                    '$tarifasTotales tarifas. El resto no tiene coords '
                    'cargadas en origen y destino.',
                    style: AppType.bodySm.copyWith(color: c.textSecondary),
                  ),
                ),
                TextButton.icon(
                  onPressed: () =>
                      _mostrarDiagnostico(context, tarifasFiltradas),
                  icon: Icon(Icons.warning_amber_outlined,
                      size: 14, color: c.warning),
                  label: Text('DIAGNÓSTICO',
                      style: AppType.eyebrow.copyWith(color: c.warning)),
                  style: TextButton.styleFrom(
                    foregroundColor: c.warning,
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: 0),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapCtl,
                      options: MapOptions(
                        initialCameraFit: CameraFit.bounds(
                          bounds: bbox,
                          padding: const EdgeInsets.all(40),
                        ),
                        minZoom: 4,
                        maxZoom: 18,
                      ),
                      children: [
                        if (_modoSatelite && MapConstants.tieneMapbox)
                          TileLayer(
                            urlTemplate: MapConstants.tileSatelliteUrl,
                            userAgentPackageName: MapConstants.userAgent,
                            maxZoom: 22,
                          )
                        else
                          TileLayer(
                            urlTemplate: MapConstants.tileUrl,
                            subdomains: MapConstants.tileSubdomains,
                            userAgentPackageName: MapConstants.userAgent,
                            maxZoom: 19,
                          ),
                        // Líneas de tarifas (debajo de los pins). Ruta OSRM
                        // si la tenemos; sino fallback a línea recta. La
                        // resaltada se dibuja ENCIMA con stroke grueso brand;
                        // las demás en brand tenue como contexto.
                        PolylineLayer(
                          polylines: _polylines(c, tarifasConCoords),
                        ),
                        // Pins en cada extremo (dedup por coord + cluster).
                        MarkerClusterLayerWidget(
                          options: MarkerClusterLayerOptions(
                            maxClusterRadius: 60,
                            size: const Size(40, 40),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.all(50),
                            markers: _buildMarkers(tarifasConCoords),
                            builder: (ctx, markers) {
                              final cc = ctx.colors;
                              return Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: cc.brand,
                                  border:
                                      Border.all(color: cc.text, width: 1.5),
                                  boxShadow: [
                                    BoxShadow(
                                      color: cc.brand.withValues(alpha: 0.6),
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Text(
                                    AppFormatters.formatearMiles(
                                        markers.length),
                                    style: AppType.mono.copyWith(
                                      color: cc.brandFg,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    // Toggle satelital flotante (solo si Mapbox configurado).
                    if (MapConstants.tieneMapbox)
                      Positioned(
                        top: AppSpacing.md,
                        right: AppSpacing.md,
                        child: _BotonMapa(
                          icono: _modoSatelite
                              ? Icons.map_outlined
                              : Icons.satellite_alt_outlined,
                          label: _modoSatelite ? 'Mapa' : 'Satélite',
                          onTap: () =>
                              setState(() => _modoSatelite = !_modoSatelite),
                        ),
                      ),
                    // Botón "VER TODAS" — visible solo con una tarifa
                    // resaltada. Limpia el resaltado y vuelve al bbox total.
                    if (_tarifaResaltadaId != null)
                      Positioned(
                        top: AppSpacing.md,
                        left: AppSpacing.md,
                        child: _BotonMapa(
                          icono: Icons.zoom_out_map,
                          label: 'Ver todas',
                          onTap: () => _verPanoramica(tarifasConCoords, bbox),
                        ),
                      ),
                    // Leyenda de colores (abajo-izquierda).
                    const Positioned(
                      left: AppSpacing.md,
                      bottom: AppSpacing.md,
                      child: AppMapLegend(
                        items: [
                          (label: 'Ruta', status: AppMarkerStatus.info),
                          (label: 'Resaltada', status: AppMarkerStatus.live),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_panelAbierto)
                _PanelLateralTarifas(
                  tarifasConCoords: tarifasConCoords,
                  tarifaResaltadaId: _tarifaResaltadaId,
                  onTapTarifa: (t) => _mostrarDetalleTarifa(context, t),
                  onCerrar: () => setState(() => _panelAbierto = false),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Construye las polylines: la resaltada al final (se dibuja arriba) con
  /// stroke grueso + color brand; las demás en brand/muted como contexto.
  List<Polyline> _polylines(
    AppColorsExt c,
    List<_TarifaConRuta> tarifasConCoords,
  ) {
    final polylines = <Polyline>[];
    Polyline? resaltada;
    for (final t in tarifasConCoords) {
      final inactiva = !t.tarifa.activa;
      final rutaReal = _rutasPorTarifa[t.tarifa.id];
      final puntos = rutaReal?.puntos ?? [t.origen, t.destino];
      final esResaltada = _tarifaResaltadaId == t.tarifa.id;
      final color = esResaltada
          ? c.brand
          : (inactiva
              ? c.textMuted
              : c.info.withValues(
                  alpha: _tarifaResaltadaId == null ? 0.7 : 0.25,
                ));
      final polyline = Polyline(
        points: puntos,
        strokeWidth: esResaltada ? 6 : 3,
        color: color,
      );
      if (esResaltada) {
        resaltada = polyline;
      } else {
        polylines.add(polyline);
      }
    }
    if (resaltada != null) polylines.add(resaltada);
    return polylines;
  }

  List<Marker> _buildMarkers(List<_TarifaConRuta> tarifas) {
    // Dedup por punto (con tolerancia). Si dos puntos están a <100m, los
    // consideramos el mismo (evita pins encimados).
    final unicos = <LatLng, String>{};
    for (final t in tarifas) {
      _addUnico(unicos, t.origen, t.nombreOrigen);
      _addUnico(unicos, t.destino, t.nombreDestino);
    }
    return unicos.entries.map((e) {
      // La etiqueta puede traer varios nombres separados por "\n" (puntos
      // combinados). Para el pill del marker usamos la primera línea.
      final primeraLinea = e.value.split('\n').first;
      return Marker(
        point: e.key,
        width: 120,
        height: 56,
        alignment: const Alignment(0, -0.4),
        child: AppMapMarker(
          label: primeraLinea,
          status: AppMarkerStatus.info,
        ),
      );
    }).toList();
  }

  void _addUnico(
    Map<LatLng, String> mapa,
    LatLng punto,
    String nombre,
  ) {
    for (final existente in mapa.keys) {
      if (LogisticaGeoUtils.distanciaKm(existente, punto) < 0.1) {
        // Mismo punto → no agregamos otro pin pero combinamos nombre.
        final actual = mapa[existente]!;
        if (!actual.contains(nombre)) {
          mapa[existente] = '$actual\n$nombre';
        }
        return;
      }
    }
    mapa[punto] = nombre;
  }

  /// Tap en una tile de tarifa: (1) resaltar la ruta en el mapa, (2)
  /// zoomear/centrar a los bounds de origen + destino con padding, y (3)
  /// abrir el sheet de detalle (que NO muestra IR AL ORIGEN/DESTINO en
  /// desktop — el operador está en oficina, no manejando).
  void _mostrarDetalleTarifa(BuildContext context, _TarifaConRuta t) {
    setState(() => _tarifaResaltadaId = t.tarifa.id);

    final puntos =
        _rutasPorTarifa[t.tarifa.id]?.puntos ?? [t.origen, t.destino];
    if (puntos.isNotEmpty) {
      final bbox = LatLngBounds.fromPoints(puntos);
      _mapCtl.fitCamera(
        CameraFit.bounds(
          bounds: bbox,
          padding: const EdgeInsets.all(60),
        ),
      );
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: context.colors.surface1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (_) => _DetalleTarifaSheet(
        tarifaConRuta: t,
        rutaReal: _rutasPorTarifa[t.tarifa.id],
      ),
    ).whenComplete(() {
      // Al cerrar el sheet, dejamos la tarifa resaltada — el operador ya
      // está mirando la ruta. Para la vista panorámica usa "Ver todas".
    });
  }

  /// Vuelve a la vista panorámica con todas las tarifas y limpia el
  /// resaltado. Llamado por el botón "VER TODAS".
  void _verPanoramica(List<_TarifaConRuta> tarifas, LatLngBounds? bbox) {
    setState(() => _tarifaResaltadaId = null);
    if (bbox != null) {
      _mapCtl.fitCamera(
        CameraFit.bounds(
          bounds: bbox,
          padding: const EdgeInsets.all(40),
        ),
      );
    }
  }
}

class _TarifaConRuta {
  final TarifaLogistica tarifa;
  final LatLng origen;
  final LatLng destino;
  final String nombreOrigen;
  final String nombreDestino;

  const _TarifaConRuta({
    required this.tarifa,
    required this.origen,
    required this.destino,
    required this.nombreOrigen,
    required this.nombreDestino,
  });

  double get distanciaKm => LogisticaGeoUtils.distanciaKm(origen, destino);
}

/// Tarifa que NO se puede mostrar en el mapa + el motivo concreto. Lo usa
/// el sheet de diagnóstico para que el operador vea exactamente qué corregir.
class _TarifaFiltrada {
  final TarifaLogistica tarifa;
  final String motivo;
  const _TarifaFiltrada({required this.tarifa, required this.motivo});
}

/// Resultado del análisis de tarifas para el mapa: las dibujables + las
/// filtradas con su motivo.
class _DiagnosticoMapa {
  final List<_TarifaConRuta> conCoords;
  final List<_TarifaFiltrada> filtradas;
  const _DiagnosticoMapa({required this.conCoords, required this.filtradas});
}

// =============================================================================
// BOTÓN FLOTANTE (toggle satélite / ver todas) — cristal Núcleo
// =============================================================================

class _BotonMapa extends StatelessWidget {
  final IconData icono;
  final String label;
  final VoidCallback onTap;
  const _BotonMapa(
      {required this.icono, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AppMapInfoPill(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono, size: 16, color: c.text),
              const SizedBox(width: AppSpacing.xs),
              Text(label,
                  style: AppType.monoSm
                      .copyWith(color: c.text, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// PANEL LATERAL — buscador token-based + lista vertical de tarifas
// =============================================================================

/// Panel lateral derecho con buscador token-based + lista vertical de
/// tarifas. El operador puede buscar por empresa/ubicación/dador/producto,
/// tocar una tile (resalta + abre detalle), o cerrar el panel. Width fijo
/// 320px. Estilo Núcleo: surface1 + hairline divisorio.
class _PanelLateralTarifas extends StatefulWidget {
  final List<_TarifaConRuta> tarifasConCoords;
  final String? tarifaResaltadaId;
  final ValueChanged<_TarifaConRuta> onTapTarifa;
  final VoidCallback onCerrar;

  const _PanelLateralTarifas({
    required this.tarifasConCoords,
    required this.tarifaResaltadaId,
    required this.onTapTarifa,
    required this.onCerrar,
  });

  @override
  State<_PanelLateralTarifas> createState() => _PanelLateralTarifasState();
}

class _PanelLateralTarifasState extends State<_PanelLateralTarifas> {
  String _filtro = '';
  final _filtroCtrl = TextEditingController();

  @override
  void dispose() {
    _filtroCtrl.dispose();
    super.dispose();
  }

  /// Filtro token-based: exige que TODOS los tokens estén presentes en algún
  /// campo de la tarifa. Mismo patrón que `LogisticaTarifasScreen`.
  List<_TarifaConRuta> _aplicar(List<_TarifaConRuta> items) {
    final q = _filtro.trim().toLowerCase();
    if (q.isEmpty) return items;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return items.where((t) {
      final hay = [
        t.tarifa.empresaOrigenNombre,
        t.tarifa.empresaDestinoNombre,
        t.tarifa.ubicacionOrigenEtiqueta,
        t.tarifa.ubicacionDestinoEtiqueta,
        t.tarifa.dadorNombre ?? '',
        t.tarifa.producto ?? '',
      ].join(' ').toLowerCase();
      for (final token in tokens) {
        if (!hay.contains(token)) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final filtradas = _aplicar(widget.tarifasConCoords);
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(left: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header con conteo + botón cerrar.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.xs, AppSpacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: AppEyebrow(
                    _filtro.isEmpty
                        ? '${widget.tarifasConCoords.length} tarifa(s)'
                        : '${filtradas.length} de ${widget.tarifasConCoords.length}',
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: c.textMuted, size: 18),
                  tooltip: 'Cerrar panel',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onCerrar,
                ),
              ],
            ),
          ),
          // Buscador.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
            child: _BuscadorPanel(
              controller: _filtroCtrl,
              tieneTexto: _filtro.isNotEmpty,
              onChanged: (v) => setState(() => _filtro = v),
              onLimpiar: () {
                _filtroCtrl.clear();
                setState(() => _filtro = '');
              },
            ),
          ),
          AppHairline(color: c.border),
          // Lista vertical.
          Expanded(
            child: filtradas.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'Sin tarifas que coincidan con la búsqueda.',
                        style: AppType.bodySm.copyWith(color: c.textMuted),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
                    itemCount: filtradas.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) => _TarifaTile(
                      tarifaConRuta: filtradas[i],
                      resaltada:
                          filtradas[i].tarifa.id == widget.tarifaResaltadaId,
                      onTap: () => widget.onTapTarifa(filtradas[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Buscador compacto del panel lateral (estilo Núcleo, denso para 320px).
class _BuscadorPanel extends StatelessWidget {
  final TextEditingController controller;
  final bool tieneTexto;
  final ValueChanged<String> onChanged;
  final VoidCallback onLimpiar;
  const _BuscadorPanel({
    required this.controller,
    required this.tieneTexto,
    required this.onChanged,
    required this.onLimpiar,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    OutlineInputBorder border(Color col) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: col),
        );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: AppType.bodySm.copyWith(color: c.text),
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.search, size: 16, color: c.textMuted),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 34, minHeight: 34),
        hintText: 'Buscar empresa, ubicación, dador…',
        hintStyle: AppType.bodySm.copyWith(color: c.textPlaceholder),
        isDense: true,
        filled: true,
        fillColor: c.surface2,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 10),
        suffixIcon: !tieneTexto
            ? null
            : IconButton(
                icon: Icon(Icons.clear, size: 15, color: c.textMuted),
                visualDensity: VisualDensity.compact,
                tooltip: 'Limpiar búsqueda',
                onPressed: onLimpiar,
              ),
        border: border(c.border),
        enabledBorder: border(c.border),
        focusedBorder: border(c.borderFocus),
      ),
    );
  }
}

/// Tile de tarifa en el panel lateral. Info en 4 líneas: ubicaciones
/// (origen ↓ destino), empresas, distancia + tarifa (mono). Resaltada =
/// tinte brand + borde brand.
class _TarifaTile extends StatelessWidget {
  final _TarifaConRuta tarifaConRuta;
  final bool resaltada;
  final VoidCallback onTap;

  const _TarifaTile({
    required this.tarifaConRuta,
    required this.resaltada,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = tarifaConRuta.tarifa;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: resaltada ? c.brand.withValues(alpha: 0.16) : c.surface2,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: resaltada ? c.brand : c.border,
            width: resaltada ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.ubicacionOrigenLimpia,
              style: AppType.bodySm
                  .copyWith(color: c.text, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                Icon(Icons.arrow_downward, size: 11, color: c.textMuted),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    t.ubicacionDestinoLimpia,
                    style: AppType.bodySm
                        .copyWith(color: c.text, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${t.empresaOrigenNombre} → ${t.empresaDestinoNombre}',
              style: AppType.monoSm.copyWith(color: c.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${tarifaConRuta.distanciaKm.toStringAsFixed(0)} km · '
              '\$ ${AppFormatters.formatearMonto(t.vigenteEn(DateTime.now()).tarifaReal)}'
              '${t.unidadTarifa.sufijoMonto}',
              style: AppType.monoSm.copyWith(
                  color: c.textSecondary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SHEET DE DETALLE DE TARIFA
// =============================================================================

class _DetalleTarifaSheet extends StatelessWidget {
  final _TarifaConRuta tarifaConRuta;
  final GeoRuta? rutaReal;
  const _DetalleTarifaSheet({
    required this.tarifaConRuta,
    this.rutaReal,
  });

  /// `true` solo en Android / iOS. En Windows desktop, web, macOS y Linux
  /// los botones "IR AL ORIGEN/DESTINO" no tienen sentido (el operador está
  /// en la oficina, no manejando) — se reemplazan por una guía textual.
  bool get _esMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = tarifaConRuta.tarifa;
    final distGeodesica = tarifaConRuta.distanciaKm;
    // Precio vigente hoy (no el campo plano) — correcto con vigencias futuras.
    final v = t.vigenteEn(DateTime.now());
    final margenBruto = v.tarifaReal - v.tarifaChofer;
    return Container(
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.border,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.price_change_outlined, color: c.brand),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          '${t.ubicacionOrigenLimpia} → ${t.ubicacionDestinoLimpia}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.h5.copyWith(color: c.text),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${tarifaConRuta.nombreOrigen}  →  ${tarifaConRuta.nombreDestino}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.bodySm.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const AppHairline(),
                  const SizedBox(height: AppSpacing.md),
                  if (rutaReal != null) ...[
                    _InfoFila(
                      icono: Icons.route_outlined,
                      etiqueta: 'Distancia por ruta',
                      valor: '${rutaReal!.distanciaKm.toStringAsFixed(0)} km',
                      mono: true,
                    ),
                    _InfoFila(
                      icono: Icons.schedule,
                      etiqueta: 'Tiempo estimado de manejo',
                      valor: rutaReal!.duracionFormateada,
                      mono: true,
                    ),
                  ] else
                    _InfoFila(
                      icono: Icons.straighten,
                      etiqueta: 'Distancia (línea recta)',
                      valor: '${distGeodesica.toStringAsFixed(0)} km',
                      mono: true,
                    ),
                  _InfoFila(
                    icono: Icons.local_shipping_outlined,
                    etiqueta: 'Tipo',
                    valor: t.tipoCarga.etiqueta,
                  ),
                  _InfoFila(
                    icono: Icons.attach_money,
                    etiqueta: 'Tarifa real / ${t.unidadTarifa.codigo}',
                    valor: '\$ ${AppFormatters.formatearMonto(v.tarifaReal)}',
                    mono: true,
                  ),
                  _InfoFila(
                    icono: Icons.payments_outlined,
                    etiqueta: 'Tarifa chofer / ${t.unidadTarifa.codigo}',
                    valor: '\$ ${AppFormatters.formatearMonto(v.tarifaChofer)}',
                    mono: true,
                  ),
                  _InfoFila(
                    icono: Icons.savings_outlined,
                    etiqueta: 'Bruto antes de gastos',
                    valor: '\$ ${AppFormatters.formatearMonto(margenBruto)}',
                    mono: true,
                  ),
                  if (t.dadorNombre != null)
                    _InfoFila(
                      icono: Icons.handshake_outlined,
                      etiqueta: 'Dador',
                      valor: '${t.dadorNombre}'
                          '${t.montoFijoDador != null ? " (\$ ${AppFormatters.formatearMonto(t.montoFijoDador!)}/viaje)" : t.porcentajeComisionDador != null ? " (${t.porcentajeComisionDador!.toStringAsFixed(1)}%)" : ""}',
                    ),
                  const SizedBox(height: AppSpacing.md),
                  const AppHairline(),
                  const SizedBox(height: AppSpacing.md),
                  // En mobile (chofer/supervisor manejando) IR AL
                  // ORIGEN/DESTINO abren Google Maps/Waze. En desktop
                  // (operador en oficina) no sirven — guía textual.
                  if (_esMobile)
                    Row(
                      children: [
                        Expanded(
                          child: AppButton.secondary(
                            label: 'Ir al origen',
                            icon: Icons.navigation_outlined,
                            size: AppButtonSize.sm,
                            expand: true,
                            onPressed: () => AccionesNavegacionSheet.abrir(
                              context,
                              lat: tarifaConRuta.origen.latitude,
                              lng: tarifaConRuta.origen.longitude,
                              label: tarifaConRuta.nombreOrigen,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: AppButton.secondary(
                            label: 'Ir al destino',
                            icon: Icons.navigation_outlined,
                            size: AppButtonSize.sm,
                            expand: true,
                            onPressed: () => AccionesNavegacionSheet.abrir(
                              context,
                              lat: tarifaConRuta.destino.latitude,
                              lng: tarifaConRuta.destino.longitude,
                              label: tarifaConRuta.nombreDestino,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Icon(Icons.alt_route, color: c.brand, size: 18),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            'Recorrido marcado en el mapa.',
                            style:
                                AppType.bodySm.copyWith(color: c.textSecondary),
                          ),
                        ),
                        AppButton.ghost(
                          label: 'Cerrar',
                          size: AppButtonSize.sm,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoFila extends StatelessWidget {
  final IconData icono;
  final String etiqueta;
  final String valor;
  final bool mono;
  const _InfoFila({
    required this.icono,
    required this.etiqueta,
    required this.valor,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, color: c.textMuted, size: 16),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              etiqueta,
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            valor,
            style: (mono ? AppType.mono : AppType.body).copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.right,
          ),
        ],
      ),
    );
  }
}
