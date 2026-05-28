// Mapa con todas las tarifas activas dibujadas sobre OpenStreetMap.
// Cada tarifa = una línea entre origen y destino. Cada extremo es un
// pin.
//
// Filtra automáticamente las tarifas que no tienen coords cargadas en
// las dos puntas (origen Y destino con lat/lng). El operador puede
// ver de un vistazo qué porción del catálogo todavía falta georreferenciar.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_geo_utils.dart';
import '../services/logistica_service.dart';
import '../widgets/acciones_navegacion_sheet.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
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
  /// progresivamente en background. La UI usa la ruta real si está,
  /// sino dibuja línea recta como fallback inmediato.
  final Map<String, GeoRuta> _rutasPorTarifa = {};

  /// Set de tarifas cuyo fetch ya disparé (para no relanzar). Distinto
  /// del cache global de `LogisticaGeoUtils` para tener visibilidad
  /// local del estado de carga sin hits en el cache externo.
  final Set<String> _yaSolicitadas = {};

  /// Id de la tarifa actualmente resaltada en el mapa (tap en su tile
  /// del panel lateral). Su polyline se dibuja más gruesa + color
  /// distinto, y el mapa hace zoom a sus bounds. null = sin resaltar
  /// (vista panorámica de todo el catálogo).
  String? _tarifaResaltadaId;

  /// Panel lateral derecho con buscador + lista de tarifas. Abierto
  /// por default (operador típico está en desktop oficina, tiene
  /// espacio). Toggle desde el botón del AppBar. Pedido Santiago
  /// 2026-05-14: con 39+ tarifas la barra horizontal inferior era
  /// incómoda — wheel del mouse mueve vertical y la lista no estaba
  /// accesible. El panel lateral con buscador resuelve volumen.
  bool _panelAbierto = true;

  @override
  void dispose() {
    _mapCtl.dispose();
    super.dispose();
  }

  /// Lanza fetch en background para cada tarifa que aún no tenga
  /// ruta local. Llamado cada vez que se reconstruye la lista de
  /// tarifas con coords (por updates del stream).
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
          icon: Icon(_panelAbierto
              ? Icons.view_sidebar_outlined
              : Icons.view_sidebar),
          tooltip: _panelAbierto ? 'Ocultar panel' : 'Mostrar panel',
          onPressed: () =>
              setState(() => _panelAbierto = !_panelAbierto),
        ),
      ],
      body: StreamBuilder<List<UbicacionLogistica>>(
        stream: LogisticaService.streamUbicaciones(),
        builder: (ctx, ubicSnap) {
          final ubicacionesPorId = {
            for (final u
                in (ubicSnap.data ?? const <UbicacionLogistica>[]))
              u.id: u,
          };
          return StreamBuilder<List<TarifaLogistica>>(
            stream: LogisticaService.streamTarifas(soloActivas: true),
            builder: (ctx, tarSnap) {
              // Errores primero — un stream caído ahora muestra mensaje
              // explícito en vez de loading infinito.
              if (tarSnap.hasError) {
                return AppEmptyState(
                  icon: Icons.error_outline,
                  title: 'Error cargando tarifas',
                  subtitle: tarSnap.error.toString(),
                );
              }
              if (ubicSnap.hasError) {
                return AppEmptyState(
                  icon: Icons.error_outline,
                  title: 'Error cargando ubicaciones',
                  subtitle: ubicSnap.error.toString(),
                );
              }
              // Spinner SOLO si NINGUNO de los dos emitió todavía.
              // Antes: si UNO estaba en waiting, bloqueaba aunque el
              // otro ya hubiera emitido — quedaba en spinner sin
              // razón cuando los streams llegaban en momentos
              // distintos (caso frecuente con Firestore live queries).
              if (!tarSnap.hasData && !ubicSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final tarifas = tarSnap.data ?? const [];
              final diag = _diagnosticar(tarifas, ubicacionesPorId);
              final tarifasConCoords = diag.conCoords;
              // Disparar precarga de rutas OSRM para todas las
              // tarifas con coords. Best-effort; las que fallan
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

  /// Devuelve el diagnóstico completo (tarifas OK + tarifas filtradas
  /// con su motivo). Lo usa el botón "Diagnóstico" del banner para
  /// listar al operador exactamente qué tarifa falla y por qué.
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

  /// Sheet con la lista de tarifas filtradas y el motivo. Útil para
  /// que el operador entienda QUÉ corregir cuando dice "tengo la
  /// tarifa cargada pero no aparece".
  void _mostrarDiagnostico(
    BuildContext context,
    List<_TarifaFiltrada> filtradas,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          builder: (ctx, controller) {
            return Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_outlined,
                          color: AppColors.warning),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Tarifas que no se muestran en el mapa',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: filtradas.length,
                    separatorBuilder: (_, __) => const Divider(
                      color: Colors.white12,
                      height: 16,
                    ),
                    itemBuilder: (_, i) {
                      final f = filtradas[i];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${f.tarifa.ubicacionOrigenLimpia} → '
                            '${f.tarifa.ubicacionDestinoLimpia}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            f.motivo,
                            style: AppType.label.copyWith(color: AppColors.warning),
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
            : OutlinedButton.icon(
                onPressed: () =>
                    _mostrarDiagnostico(context, tarifasFiltradas),
                icon: const Icon(Icons.warning_amber_outlined),
                label: const Text('VER DIAGNÓSTICO'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.warning,
                  side: const BorderSide(color: AppColors.warning),
                ),
              ),
      );
    }

    // Calcular bbox para encuadre inicial. Si hay un solo punto la
    // bbox queda chica — flutter_map lo maneja con padding.
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
            color: Colors.white10,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    color: AppColors.warning, size: 16),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Mostrando ${tarifasConCoords.length} de '
                    '$tarifasTotales tarifas. El resto no tiene coords '
                    'cargadas en origen y destino.',
                    style: AppType.label.copyWith(color: Colors.white70),
                  ),
                ),
                TextButton.icon(
                  onPressed: () =>
                      _mostrarDiagnostico(context, tarifasFiltradas),
                  icon: const Icon(Icons.warning_amber_outlined, size: 14),
                  label: const Text(
                    'DIAGNÓSTICO',
                    style: AppType.eyebrow,
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.warning,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 0,
                    ),
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
              // Líneas de tarifas (debajo de los pins). Si ya tenemos
              // la ruta OSRM (siguen las carreteras) la usamos; sino
              // fallback a línea recta entre origen y destino.
              //
              // La tarifa resaltada (la que el operador eligió tocando
              // su tile en la franja inferior) se dibuja **encima**
              // del resto y con stroke más grueso + color naranja para
              // destacarla. Las demás quedan en verde tenue como
              // contexto.
              PolylineLayer(
                polylines: () {
                  final polylines = <Polyline>[];
                  Polyline? resaltada;
                  for (final t in tarifasConCoords) {
                    final inactiva = !t.tarifa.activa;
                    final rutaReal = _rutasPorTarifa[t.tarifa.id];
                    final puntos = rutaReal?.puntos ?? [t.origen, t.destino];
                    final esResaltada =
                        _tarifaResaltadaId == t.tarifa.id;
                    final color = esResaltada
                        ? AppColors.warning
                        : (inactiva
                            ? Colors.white24
                            : AppColors.success.withValues(
                                alpha: _tarifaResaltadaId == null
                                    ? 0.7
                                    : 0.25,
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
                  // La resaltada al final → se dibuja arriba del resto.
                  if (resaltada != null) polylines.add(resaltada);
                  return polylines;
                }(),
              ),
              // Pins en cada extremo (deduplicados por coord +
              // agrupados con cluster cuando se solapan a bajo
              // zoom). El cluster muestra "5" o "12" según cantidad
              // y al hacer tap se zoomea.
              MarkerClusterLayerWidget(
                options: MarkerClusterLayerOptions(
                  maxClusterRadius: 60,
                  size: const Size(40, 40),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(50),
                  markers: _buildMarkers(tarifasConCoords),
                  builder: (ctx, markers) => Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.info,
                    ),
                    child: Center(
                      child: Text(
                        markers.length.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
              // Toggle satelital flotante. Solo si Mapbox está configurado.
              if (MapConstants.tieneMapbox)
                Positioned(
                  top: 12,
                  right: 12,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: () => setState(
                          () => _modoSatelite = !_modoSatelite),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _modoSatelite
                                  ? Icons.map_outlined
                                  : Icons.satellite_alt_outlined,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _modoSatelite ? 'MAPA' : 'SATÉLITE',
                              style: AppType.eyebrow.copyWith(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Botón "VER TODAS" — visible solo si hay una tarifa
              // resaltada. Limpia el resaltado y vuelve al bounding
              // box del catálogo completo.
              if (_tarifaResaltadaId != null)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Material(
                    color: AppColors.warning.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: () => _verPanoramica(tarifasConCoords, bbox),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.zoom_out_map,
                                color: Colors.white, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              'VER TODAS',
                              style: AppType.eyebrow.copyWith(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                  ],
                ),
              ),
              if (_panelAbierto)
                _PanelLateralTarifas(
                  tarifasConCoords: tarifasConCoords,
                  tarifaResaltadaId: _tarifaResaltadaId,
                  onTapTarifa: (t) =>
                      _mostrarDetalleTarifa(context, t),
                  onCerrar: () =>
                      setState(() => _panelAbierto = false),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Marker> _buildMarkers(List<_TarifaConRuta> tarifas) {
    // Dedup por punto (con tolerancia). Si dos puntos están a
    // <100m, los consideramos el mismo (evita pins encimados).
    final unicos = <LatLng, String>{};
    for (final t in tarifas) {
      _addUnico(unicos, t.origen, t.nombreOrigen);
      _addUnico(unicos, t.destino, t.nombreDestino);
    }
    return unicos.entries.map((e) {
      return Marker(
        point: e.key,
        width: 30,
        height: 30,
        child: Tooltip(
          message: e.value,
          child: const Icon(
            Icons.location_on,
            color: AppColors.info,
            size: 30,
          ),
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
        // Mismo punto → no agregamos otro pin pero combinamos nombre
        final actual = mapa[existente]!;
        if (!actual.contains(nombre)) {
          mapa[existente] = '$actual\n$nombre';
        }
        return;
      }
    }
    mapa[punto] = nombre;
  }

  /// Tap en una tile de tarifa: (1) resaltar visualmente la ruta en
  /// el mapa, (2) zoomear/centrar el mapa a los bounds de origen +
  /// destino con padding, y (3) abrir el sheet de detalle (que NO
  /// muestra los botones IR AL ORIGEN/DESTINO en Windows desktop —
  /// el operador está en oficina, no manejando).
  ///
  /// Para volver a la vista panorámica de todo el catálogo, el
  /// operador cierra el sheet y toca cualquier zona vacía / o toca
  /// otra tile.
  void _mostrarDetalleTarifa(BuildContext context, _TarifaConRuta t) {
    // Resaltar la tarifa en el mapa.
    setState(() => _tarifaResaltadaId = t.tarifa.id);

    // Centrar el mapa en el bounding box de la tarifa. Si tenemos
    // ruta real, usamos sus puntos (más preciso); sino origen+destino.
    final puntos = _rutasPorTarifa[t.tarifa.id]?.puntos ?? [t.origen, t.destino];
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
      backgroundColor: AppColors.background,
      builder: (_) => _DetalleTarifaSheet(
        tarifaConRuta: t,
        rutaReal: _rutasPorTarifa[t.tarifa.id],
      ),
    ).whenComplete(() {
      // Al cerrar el sheet, dejamos la tarifa todavía resaltada — el
      // operador ya está mirando la ruta. Para volver a la vista
      // panorámica puede tocar el botón "Ver todas" (arriba).
    });
  }

  /// Vuelve a la vista panorámica con todas las tarifas y limpia el
  /// resaltado. Llamado por el botón "VER TODAS" arriba del mapa.
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

/// Tarifa que NO se puede mostrar en el mapa + el motivo concreto.
/// Lo usa el sheet de diagnóstico para que el operador vea
/// exactamente qué corregir (ej. "la ubicación origen no tiene
/// coords cargadas" en lugar del genérico "sin georreferenciar").
class _TarifaFiltrada {
  final TarifaLogistica tarifa;
  final String motivo;
  const _TarifaFiltrada({required this.tarifa, required this.motivo});
}

/// Resultado del análisis de tarifas para el mapa: las que se pueden
/// dibujar + las filtradas con su motivo.
class _DiagnosticoMapa {
  final List<_TarifaConRuta> conCoords;
  final List<_TarifaFiltrada> filtradas;
  const _DiagnosticoMapa({required this.conCoords, required this.filtradas});
}

/// Panel lateral derecho con buscador token-based + lista vertical
/// de tarifas. Reemplazó la barra inferior horizontal el 2026-05-14
/// (Santiago: con 39+ tarifas la barra horizontal era incómoda —
/// scroll horizontal en desktop con wheel del mouse no funciona).
///
/// El operador puede:
///   - Buscar por empresa/ubicación/dador/producto (token-based,
///     match en TODOS los tokens). Misma UX que el selector de
///     tarifa en el form de viaje.
///   - Tap en una tile → resalta la ruta en el mapa + abre detalle.
///   - Cerrar el panel para ver el mapa full (botón X arriba o
///     toggle desde el AppBar).
///
/// Width fijo 320px. En screens muy angostas (mobile chico) ocupa
/// más proporción del width pero se mantiene usable. Si Vecchi
/// arranca a operar el mapa desde celulares, evaluar Drawer modal.
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

  /// Filtro token-based: exige que TODOS los tokens estén presentes
  /// en algún campo de la tarifa. Permite buscar "profertil olavarria"
  /// y matchear empresa Profertil + destino Olavarría. Mismo patrón
  /// que `LogisticaTarifasScreen._aplicarFiltro`.
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
    final filtradas = _aplicar(widget.tarifasConCoords);
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        border: Border(
          left: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header con conteo + botón cerrar.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _filtro.isEmpty
                        ? '${widget.tarifasConCoords.length} TARIFA(S)'
                        : '${filtradas.length} de ${widget.tarifasConCoords.length}',
                    style: AppType.eyebrow.copyWith(color: Colors.white70, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                  tooltip: 'Cerrar panel',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onCerrar,
                ),
              ],
            ),
          ),
          // Buscador.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _filtroCtrl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: 'Buscar empresa, ubicación, dador…',
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 10),
                suffixIcon: _filtro.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Limpiar búsqueda',
                        onPressed: () {
                          _filtroCtrl.clear();
                          setState(() => _filtro = '');
                        },
                      ),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => setState(() => _filtro = v),
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          // Lista vertical.
          Expanded(
            child: filtradas.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'Sin tarifas que coincidan con la búsqueda.',
                        style: AppType.label.copyWith(color: Colors.white54),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    itemCount: filtradas.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) => _TarifaTile(
                      tarifaConRuta: filtradas[i],
                      resaltada: filtradas[i].tarifa.id ==
                          widget.tarifaResaltadaId,
                      onTap: () => widget.onTapTarifa(filtradas[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Tile de tarifa en el panel lateral. Más alto que ancho, con info
/// completa en 4 líneas: tipo, ubicaciones (origen → destino),
/// empresas, distancia + tarifa.
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
    final t = tarifaConRuta.tarifa;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: resaltada
              ? AppColors.success.withValues(alpha: 0.18)
              : Colors.white10,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: resaltada
                ? AppColors.success
                : AppColors.success.withValues(alpha: 0.3),
            width: resaltada ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.ubicacionOrigenLimpia,
              style: AppType.label.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                const Icon(Icons.arrow_downward,
                    size: 11, color: Colors.white38),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    t.ubicacionDestinoLimpia,
                    style: AppType.label.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${t.empresaOrigenNombre} → ${t.empresaDestinoNombre}',
              style: const TextStyle(color: Colors.white54, fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${tarifaConRuta.distanciaKm.toStringAsFixed(0)} km · '
              '\$${AppFormatters.formatearMonto(t.tarifaReal)}'
              '/${t.unidadTarifa.codigo}',
              style: AppType.eyebrow.copyWith(color: AppColors.success, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetalleTarifaSheet extends StatelessWidget {
  final _TarifaConRuta tarifaConRuta;
  final GeoRuta? rutaReal;
  const _DetalleTarifaSheet({
    required this.tarifaConRuta,
    this.rutaReal,
  });

  /// `true` solo en Android / iOS. En Windows desktop, web, macOS y
  /// Linux los botones "IR AL ORIGEN/DESTINO" no tienen sentido (el
  /// operador está en la oficina, no manejando) — se reemplazan por
  /// una guía textual.
  bool get _esMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  @override
  Widget build(BuildContext context) {
    final t = tarifaConRuta.tarifa;
    final distGeodesica = tarifaConRuta.distanciaKm;
    final margenBruto = t.tarifaReal - t.tarifaChofer;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.price_change_outlined,
                  color: AppColors.success),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '${t.ubicacionOrigenLimpia} → ${t.ubicacionDestinoLimpia}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.heading.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${tarifaConRuta.nombreOrigen}  →  ${tarifaConRuta.nombreDestino}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.label.copyWith(color: Colors.white60),
          ),
          const Divider(color: Colors.white12, height: 24),
          if (rutaReal != null) ...[
            _InfoFila(
              icono: Icons.route_outlined,
              etiqueta: 'Distancia por ruta',
              valor: '${rutaReal!.distanciaKm.toStringAsFixed(0)} km',
            ),
            _InfoFila(
              icono: Icons.schedule,
              etiqueta: 'Tiempo estimado de manejo',
              valor: rutaReal!.duracionFormateada,
            ),
          ] else
            _InfoFila(
              icono: Icons.straighten,
              etiqueta: 'Distancia (línea recta)',
              valor: '${distGeodesica.toStringAsFixed(0)} km',
            ),
          _InfoFila(
            icono: Icons.local_shipping_outlined,
            etiqueta: 'Tipo',
            valor: t.tipoCarga.etiqueta,
          ),
          _InfoFila(
            icono: Icons.attach_money,
            etiqueta: 'Tarifa real / ${t.unidadTarifa.codigo}',
            valor: AppFormatters.formatearMonto(t.tarifaReal),
          ),
          _InfoFila(
            icono: Icons.payments_outlined,
            etiqueta: 'Tarifa chofer / ${t.unidadTarifa.codigo}',
            valor: AppFormatters.formatearMonto(t.tarifaChofer),
          ),
          _InfoFila(
            icono: Icons.savings_outlined,
            etiqueta: 'Bruto antes de gastos',
            valor: AppFormatters.formatearMonto(margenBruto),
          ),
          if (t.dadorNombre != null)
            _InfoFila(
              icono: Icons.handshake_outlined,
              etiqueta: 'Dador',
              valor: '${t.dadorNombre}'
                  '${t.montoFijoDador != null ? " (\$ ${AppFormatters.formatearMonto(t.montoFijoDador!)}/viaje)" : t.porcentajeComisionDador != null ? " (${t.porcentajeComisionDador!.toStringAsFixed(1)}%)" : ""}',
            ),
          const Divider(color: Colors.white12, height: 24),
          // En **mobile** (chofer/supervisor manejando) los botones
          // "IR AL ORIGEN/DESTINO" tienen sentido: abren Google Maps
          // o Waze con el destino fijado para llegar manejando.
          //
          // En **Windows desktop** el operador está en la oficina
          // mirando el catálogo de tarifas — esos botones no sirven
          // para nada. En su lugar mostramos un texto guía
          // explicando que la ruta ya quedó resaltada en el mapa.
          if (_esMobile)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => AccionesNavegacionSheet.abrir(
                      context,
                      lat: tarifaConRuta.origen.latitude,
                      lng: tarifaConRuta.origen.longitude,
                      label: tarifaConRuta.nombreOrigen,
                    ),
                    icon: const Icon(Icons.navigation_outlined, size: 16),
                    label: const Text('IR AL ORIGEN'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.info,
                      side: const BorderSide(color: AppColors.info),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => AccionesNavegacionSheet.abrir(
                      context,
                      lat: tarifaConRuta.destino.latitude,
                      lng: tarifaConRuta.destino.longitude,
                      label: tarifaConRuta.nombreDestino,
                    ),
                    icon: const Icon(Icons.navigation_outlined, size: 16),
                    label: const Text('IR AL DESTINO'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.brandSoft,
                      side: const BorderSide(color: AppColors.brandSoft),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                const Icon(Icons.alt_route,
                    color: AppColors.warning, size: 18),
                const SizedBox(width: AppSpacing.sm),
                const Expanded(
                  child: Text(
                    'Recorrido marcado en el mapa.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('CERRAR'),
                ),
              ],
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
  const _InfoFila({
    required this.icono,
    required this.etiqueta,
    required this.valor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icono, color: Colors.white54, size: 16),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              etiqueta,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          Text(
            valor,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
