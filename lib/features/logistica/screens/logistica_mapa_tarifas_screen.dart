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
  /// de la franja inferior). Su polyline se dibuja más gruesa + color
  /// distinto, y el mapa hace zoom a sus bounds. null = sin resaltar
  /// (vista panorámica de todo el catálogo).
  String? _tarifaResaltadaId;

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
              final tarifasConCoords = _filtrarConCoords(
                tarifas,
                ubicacionesPorId,
              );
              // Disparar precarga de rutas OSRM para todas las
              // tarifas con coords. Best-effort; las que fallan
              // quedan con línea recta.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _precargarRutas(tarifasConCoords);
              });
              return _buildMapa(
                context,
                tarifasConCoords: tarifasConCoords,
                tarifasTotales: tarifas.length,
                ubicacionesPorId: ubicacionesPorId,
              );
            },
          );
        },
      ),
    );
  }

  /// Filtra tarifas activas con ubicaciones origen+destino cargadas y
  /// con coords en ambas puntas. Las restantes (sin coords) se cuentan
  /// aparte para mostrar "X de Y tarifas sin georreferenciar".
  List<_TarifaConRuta> _filtrarConCoords(
    List<TarifaLogistica> tarifas,
    Map<String, UbicacionLogistica> ubicaciones,
  ) {
    final res = <_TarifaConRuta>[];
    for (final t in tarifas) {
      final o = ubicaciones[t.ubicacionOrigenId];
      final d = ubicaciones[t.ubicacionDestinoId];
      if (o?.lat == null || o?.lng == null) continue;
      if (d?.lat == null || d?.lng == null) continue;
      res.add(_TarifaConRuta(
        tarifa: t,
        origen: LatLng(o!.lat!, o.lng!),
        destino: LatLng(d!.lat!, d.lng!),
        nombreOrigen: o.nombre,
        nombreDestino: d.nombre,
      ));
    }
    return res;
  }

  Widget _buildMapa(
    BuildContext context, {
    required List<_TarifaConRuta> tarifasConCoords,
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
                'origen y destino georreferenciado. Editá las ubicaciones y '
                'agregá coordenadas con el botón "Elegir en mapa".',
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
                    color: AppColors.accentAmber, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Mostrando ${tarifasConCoords.length} de '
                    '$tarifasTotales tarifas. El resto no tiene coords '
                    'cargadas en origen y destino.',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
                        ? AppColors.accentOrange
                        : (inactiva
                            ? Colors.white24
                            : AppColors.accentGreen.withValues(
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
                      color: AppColors.accentBlue,
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
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
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
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.1,
                              ),
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
                    color: AppColors.accentOrange.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _verPanoramica(tarifasConCoords, bbox),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.zoom_out_map,
                                color: Colors.white, size: 18),
                            SizedBox(width: 6),
                            Text(
                              'VER TODAS',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.1,
                              ),
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
        _LeyendaInferior(
          tarifasConCoords: tarifasConCoords,
          ubicacionesPorId: ubicacionesPorId,
          onTapTarifa: (t) => _mostrarDetalleTarifa(context, t),
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
            color: AppColors.accentBlue,
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

/// Leyenda inferior con conteo + lista resumida de tarifas
/// (tappeable para ver detalle). Diseñada para no ocupar mucho — el
/// foco está en el mapa.
class _LeyendaInferior extends StatelessWidget {
  final List<_TarifaConRuta> tarifasConCoords;
  // ignore: unused_element_parameter
  final Map<String, UbicacionLogistica> ubicacionesPorId;
  final ValueChanged<_TarifaConRuta> onTapTarifa;

  const _LeyendaInferior({
    required this.tarifasConCoords,
    required this.ubicacionesPorId,
    required this.onTapTarifa,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black26,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${tarifasConCoords.length} TARIFA(S) EN EL MAPA',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: tarifasConCoords.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final t = tarifasConCoords[i];
                return GestureDetector(
                  onTap: () => onTapTarifa(t),
                  child: Container(
                    // 200 → 180: dos tiles + spacing entran en mobile.
                    width: 180,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.accentGreen.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${t.tarifa.empresaOrigenNombre} → '
                          '${t.tarifa.empresaDestinoNombre}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${t.distanciaKm.toStringAsFixed(0)} km · '
                          '${AppFormatters.formatearMonto(t.tarifa.tarifaReal)}'
                          '/${t.tarifa.unidadTarifa.codigo}',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                        ),
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
                  color: AppColors.accentGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${t.empresaOrigenNombre} → ${t.empresaDestinoNombre}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${tarifaConRuta.nombreOrigen}  →  ${tarifaConRuta.nombreDestino}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
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
                  '${t.porcentajeComisionDador != null ? " (${t.porcentajeComisionDador!.toStringAsFixed(1)}%)" : ""}',
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
                      foregroundColor: AppColors.accentBlue,
                      side: const BorderSide(color: AppColors.accentBlue),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
                      foregroundColor: AppColors.accentTeal,
                      side: const BorderSide(color: AppColors.accentTeal),
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
                    color: AppColors.accentOrange, size: 18),
                const SizedBox(width: 8),
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
          const SizedBox(width: 8),
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
