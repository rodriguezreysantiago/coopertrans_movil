// Bottom sheet para elegir un punto geográfico sobre OpenStreetMap.
//
// Flujo:
//   1. Operador toca "Elegir en mapa" en el form de ubicación.
//   2. Se abre este sheet con el mapa centrado (en el punto actual si
//      existía, o en Bahía Blanca como default — base operativa de
//      Vecchi).
//   3. Operador puede:
//      - Buscar por texto (Nominatim) → la lista de resultados centra
//        el mapa al elegir.
//      - Mover el mapa → el crosshair central marca el punto.
//      - Tocar "Confirmar" → al volver, el caller recibe lat/lng +
//        localidad/provincia/dirección del reverse geocoding.
//
// Decisión: crosshair fijo (no marker arrastrable). Más simple
// visualmente y evita confusiones de gesture (el mapa se mueve
// debajo del crosshair, el centro siempre es el punto).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../services/logistica_geo_utils.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
class UbicacionMapPickerResultado {
  final LatLng punto;
  final String? localidad;
  final String? provincia;
  final String? direccion;

  const UbicacionMapPickerResultado({
    required this.punto,
    this.localidad,
    this.provincia,
    this.direccion,
  });
}

class UbicacionMapPicker extends StatefulWidget {
  final LatLng? puntoInicial;
  final String? hintBusqueda;

  const UbicacionMapPicker({
    super.key,
    this.puntoInicial,
    this.hintBusqueda,
  });

  /// Helper para abrir el picker como bottom sheet y devolver el
  /// resultado. Devuelve null si el operador cancela.
  static Future<UbicacionMapPickerResultado?> abrir(
    BuildContext context, {
    LatLng? puntoInicial,
    String? hintBusqueda,
  }) {
    return showModalBottomSheet<UbicacionMapPickerResultado>(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (_) => UbicacionMapPicker(
        puntoInicial: puntoInicial,
        hintBusqueda: hintBusqueda,
      ),
    );
  }

  @override
  State<UbicacionMapPicker> createState() => _UbicacionMapPickerState();
}

class _UbicacionMapPickerState extends State<UbicacionMapPicker> {
  // Default: Bahía Blanca, base operativa de Vecchi. Si el operador
  // está editando una ubicación que ya tenía coords, arrancamos ahí.
  static const _defaultBahiaBlanca = LatLng(-38.7167, -62.2667);

  late final MapController _mapCtl;
  late LatLng _puntoCentral;
  final _busquedaCtl = TextEditingController();
  Timer? _debounce;
  List<GeoLugar> _resultados = const [];
  bool _buscando = false;
  bool _confirmando = false;
  String? _errorBusqueda;
  /// Modo satelital. Útil para identificar silos / galpones / accesos
  /// rurales por aspecto físico. Default = false (mapa callejero).
  bool _modoSatelite = false;

  @override
  void initState() {
    super.initState();
    _mapCtl = MapController();
    _puntoCentral = widget.puntoInicial ?? _defaultBahiaBlanca;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _busquedaCtl.dispose();
    _mapCtl.dispose();
    super.dispose();
  }

  void _onCambioBusqueda(String q) {
    _debounce?.cancel();
    if (q.trim().length < 3) {
      setState(() {
        _resultados = const [];
        _errorBusqueda = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      setState(() {
        _buscando = true;
        _errorBusqueda = null;
      });
      try {
        final hits = await LogisticaGeoUtils.buscar(q);
        if (!mounted) return;
        setState(() {
          _resultados = hits;
          _buscando = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _resultados = const [];
          _buscando = false;
          _errorBusqueda = 'No pude buscar (sin red?). Probá de nuevo.';
        });
      }
    });
  }

  void _seleccionarResultado(GeoLugar lugar) {
    FocusScope.of(context).unfocus();
    setState(() {
      _puntoCentral = lugar.punto;
      _resultados = const [];
      _busquedaCtl.text = lugar.displayName.split(',').take(2).join(',').trim();
    });
    _mapCtl.move(lugar.punto, 13);
  }

  /// Pide al operador pegar un link de Google Maps. Parsea las
  /// coordenadas del link y centra el mapa ahí. Útil para puntos
  /// rurales que no aparecen en la búsqueda nativa (Mapbox / Nominatim
  /// los suelen tener mal o falta de POI). Workflow típico:
  ///   1. Operador busca el silo en Google Maps web (https://maps.google.com)
  ///   2. Click derecho sobre el pin → "Compartir ubicación" o copiar URL
  ///   3. Pega el link en este dialog
  ///   4. App extrae lat/lng y centra el mapa
  Future<void> _pegarLinkGoogleMaps() async {
    final ctrl = TextEditingController();
    final String? url;
    try {
      url = await showDialog<String>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            backgroundColor: AppColors.background,
            title: const Text('Pegar link de Google Maps'),
            content: SizedBox(
              width: (MediaQuery.of(ctx).size.width - 80).clamp(240.0, 400.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Buscá el lugar en Google Maps web, copiá el enlace y pegalo acá. Se extraen automáticamente las coordenadas.',
                    style: AppType.label.copyWith(color: Colors.white60),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'URL de Google Maps',
                      hintText:
                          'https://maps.app.goo.gl/... o https://www.google.com/maps/...',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Acepta links largos (con @lat,lng) y links cortos (maps.app.goo.gl).',
                    style: AppType.eyebrow.copyWith(color: Colors.white38),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('CANCELAR'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('USAR ESTE LINK'),
              ),
            ],
          );
        },
      );
    } finally {
      ctrl.dispose();
    }
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    setState(() => _confirmando = true);
    try {
      final punto = await LogisticaGeoUtils.parsearUrlGoogleMaps(url);
      if (!mounted) return;
      setState(() => _confirmando = false);
      if (punto == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No pude extraer las coordenadas del link. '
              'Probá con un link distinto (busca el lugar y compartí el link).',
            ),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }
      setState(() => _puntoCentral = punto);
      _mapCtl.move(punto, 16);
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirmando = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo procesar el link: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Pide permiso de GPS al usuario (si hace falta), captura la
  /// ubicación actual y centra el mapa ahí. Para Android/iOS — en
  /// Windows desktop el plugin geolocator devuelve error porque no
  /// hay backend de GPS estándar; ahí mostramos snackbar y volvemos.
  Future<void> _usarMiUbicacion() async {
    // Solo Android/iOS soportan GPS de forma confiable. En desktop
    // el plugin no tiene backend.
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Esta función solo está disponible en Android e iOS. '
            'En la PC, mové el mapa o pegá las coords manualmente.',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    try {
      // Verificar/pedir permiso de location.
      var permiso = await Geolocator.checkPermission();
      if (permiso == LocationPermission.denied) {
        permiso = await Geolocator.requestPermission();
      }
      if (permiso == LocationPermission.denied ||
          permiso == LocationPermission.deniedForever) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Permiso de ubicación denegado. Activalo en '
              'Configuración → Apps → Coopertrans Móvil.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }
      // Verificar que el GPS esté prendido en el device.
      final servActivo = await Geolocator.isLocationServiceEnabled();
      if (!servActivo) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'El GPS está apagado. Prendelo y reintentá.',
            ),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
      // Capturar posición. Aceptamos precisión media — buscamos un
      // pin aproximado, no tracking. Timeout corto: si tarda >10s,
      // probablemente está en interior sin señal.
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;
      final punto = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _puntoCentral = punto;
      });
      _mapCtl.move(punto, 16);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo obtener tu ubicación: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _confirmar() async {
    setState(() => _confirmando = true);
    GeoLugar? reverso;
    try {
      reverso = await LogisticaGeoUtils.reverso(_puntoCentral);
    } catch (_) {
      // Best-effort: si reverse falla (sin red), devolvemos solo
      // las coords. El operador puede llenar localidad/provincia
      // a mano.
      reverso = null;
    }
    if (!mounted) return;
    Navigator.pop(
      context,
      UbicacionMapPickerResultado(
        punto: _puntoCentral,
        localidad: reverso?.localidad,
        provincia: reverso?.provincia,
        direccion: reverso?.direccion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.95,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (ctx, scrollController) => Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header con título
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Icon(Icons.map_outlined, color: AppColors.info),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Elegir punto en el mapa',
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
          // Buscador + sugerencias
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _busquedaCtl,
              onChanged: _onCambioBusqueda,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.hintBusqueda ?? 'Buscar lugar (ej. Tres Arroyos)',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                suffixIcon: _buscando
                    ? const Padding(
                        padding: EdgeInsets.all(AppSpacing.md),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.info,
                          ),
                        ),
                      )
                    : (_busquedaCtl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close, color: Colors.white54),
                            tooltip: 'Limpiar búsqueda',
                            onPressed: () {
                              _busquedaCtl.clear();
                              setState(() => _resultados = const []);
                            },
                          )
                        : null),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_errorBusqueda != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _errorBusqueda!,
                style: AppType.label.copyWith(color: AppColors.error),
              ),
            ),
          if (_resultados.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _resultados.length,
                separatorBuilder: (_, __) => const Divider(
                  height: 1,
                  color: Colors.white12,
                ),
                itemBuilder: (_, i) {
                  final r = _resultados[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined,
                        color: Colors.white54, size: 18),
                    title: Text(
                      r.displayName,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _seleccionarResultado(r),
                  );
                },
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          // Mapa con crosshair fijo
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                FlutterMap(
                  mapController: _mapCtl,
                  options: MapOptions(
                    initialCenter: _puntoCentral,
                    initialZoom: widget.puntoInicial != null ? 13 : 6,
                    minZoom: 4,
                    maxZoom: 18,
                    onPositionChanged: (pos, _) {
                      // Capturar el centro continuamente para que el
                      // confirmar use el punto donde quedó el mapa.
                      _puntoCentral = pos.center;
                    },
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
                  ],
                ),
                // Toggle satelital flotante arriba a la derecha.
                // Solo visible si Mapbox está configurado — si no hay
                // token, el satelital no funciona y mejor no mostrarlo.
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
                // Crosshair central
                IgnorePointer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.info.withValues(alpha: 0.2),
                          border: Border.all(
                            color: AppColors.info,
                            width: 2,
                          ),
                        ),
                      ),
                      // Espacio igual a la mitad de la altura del pin
                      // para alinear con la base del marker visual.
                      const SizedBox(height: AppSpacing.xs),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Footer con coords actuales + botones
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            color: Colors.black26,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Builder(builder: (_) {
                  return Text(
                    'Punto seleccionado: '
                    '${_puntoCentral.latitude.toStringAsFixed(5)}, '
                    '${_puntoCentral.longitude.toStringAsFixed(5)}',
                    style: AppType.label.copyWith(color: Colors.white70),
                    textAlign: TextAlign.center,
                  );
                }),
                const SizedBox(height: AppSpacing.sm),
                // 2 atajos: GPS (solo mobile) + pegar link de Google
                // Maps. El segundo es la salvación para puntos rurales
                // que Mapbox / Nominatim no encuentran — el operador
                // los busca en Google Maps web, copia el link, y la
                // app extrae las coords.
                Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: _confirmando ? null : _usarMiUbicacion,
                      icon: const Icon(Icons.my_location, size: 18),
                      label: const Text('USAR MI UBICACIÓN'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.brandSoft,
                      ),
                    ),
                    TextButton.icon(
                      onPressed:
                          _confirmando ? null : _pegarLinkGoogleMaps,
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('PEGAR LINK GOOGLE MAPS'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.info,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _confirmando
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('CANCELAR'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _confirmando ? null : _confirmar,
                        icon: _confirmando
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check),
                        label: const Text('CONFIRMAR'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.info,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
